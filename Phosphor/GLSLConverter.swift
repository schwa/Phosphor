import SwiftTreeSitter
import TreeSitterCPP

struct GLSLConverter {

    let source = "o++;vec3 p,c=vec3(8,6,7)/6e2;for(float q=2.,e,i,a,g,h,k;i++<2e2;g+=a=min(e,h-q)/3.,o-=mix(c.ggbr,c.rgrr+h/7e2,h-q)/exp(a*a*1e7)/h)for(p=vec3((FC.xy-r/q)/r.y*g,g),e=p.y-g*.7+q,p.z+=t,h=e+p.x*.4,a=q;a<5e2;a/=.8)p.xz*=rotate2D(q),h-=exp(sin(k=p.z*a)/a-1.)-.44,e-=exp(sin(k+t+t)-q)/a;"

    func convert(source: String) throws -> String {
        let cppConfig = try LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        let parser = Parser()
        try parser.setLanguage(cppConfig.language)
//        guard let rootNode = tree.rootNode else {
//            fatalError()
//        }




        return ""
    }
}
